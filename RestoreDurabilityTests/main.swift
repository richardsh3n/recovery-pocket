import Foundation
import Darwin
var checks=0
func check(_ condition:@autoclosure()->Bool,_ name:String){precondition(condition(),name);checks+=1;print("PASS: "+name)}
let names=["energy-budget-manual.json","events-v1.json","integrated-v1.json"]
func payload(_ root:URL)->[URL:Data] {Dictionary(uniqueKeysWithValues:names.map{(root.appendingPathComponent($0),Data(("new-"+$0).utf8))})}
func prepare(_ root:URL,missing:String?=nil)throws {
 try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
 for name in names where name != missing {try Data(("old-"+name).utf8).write(to:root.appendingPathComponent(name))}
}
if CommandLine.arguments.count>=4,CommandLine.arguments[1]=="--kill" {
 let stage=CommandLine.arguments[2],root=URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
 try ManualRecordTransaction.commit(payload(root),onCheckpoint:{checkpoint in
  let shouldExit:Bool
  switch checkpoint {case .prepared:shouldExit=stage=="prepared";case .wroteFile(let n):shouldExit=stage=="write-\(n)";case .committed:shouldExit=stage=="committed"}
  if shouldExit {exit(97)}
 })
 exit(98)
}
if CommandLine.arguments.count>=4,CommandLine.arguments[1]=="--rollback-kill" {
 let index=Int(CommandLine.arguments[2])!,directory=URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
 _ = try ManualRecordTransaction.recover(in:directory,onRollbackFile:{if $0==index {exit(97)}})
 exit(98)
}
if CommandLine.arguments.count>=3,CommandLine.arguments[1]=="--hold" {
 let root=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
 let fd=open(root.appendingPathComponent("manual-records.lock").path,O_CREAT|O_RDWR,S_IRUSR|S_IWUSR)
 guard fd>=0,flock(fd,LOCK_EX|LOCK_NB)==0 else{exit(96)}
 FileHandle.standardOutput.write(Data("locked\n".utf8))
 let deadline=Date().addingTimeInterval(5)
 while !FileManager.default.fileExists(atPath:root.appendingPathComponent("release").path),Date()<deadline {Thread.sleep(forTimeInterval:0.02)}
 flock(fd,LOCK_UN);close(fd);exit(0)
}
let root=FileManager.default.temporaryDirectory.appendingPathComponent("pocket-restore-durability-"+UUID().uuidString,isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:root)}
func folder(_ name:String)->URL {root.appendingPathComponent(name,isDirectory:true)}
func child(_ stage:String,_ directory:URL)throws {
 let process=Process();process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);process.arguments=["--kill",stage,directory.path]
 let output=Pipe();process.standardOutput=output;process.standardError=output
 try process.run();process.waitUntilExit()
 let log=String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
 check(process.terminationStatus==97,"child actually exited at \(stage), not caught exception: \(log.prefix(100))")
}
func contents(_ directory:URL)->[String:Data] {
 Dictionary(uniqueKeysWithValues:names.compactMap{name in (try? Data(contentsOf:directory.appendingPathComponent(name))).map{(name,$0)}})
}
func throwsError(_ operation:()throws->Void)->Bool {do{try operation();return false}catch{return true}}
var scenarios:[[String:Any]]=[]
for stage in ["prepared","write-1","write-2","write-3","committed"] {
 let directory=folder(stage);try prepare(directory);let before=contents(directory)
 try child(stage,directory)
 let journal=directory.appendingPathComponent("manual-restore-journal-v1.json")
 check(FileManager.default.fileExists(atPath:journal.path),"\(stage) leaves durable recovery metadata across process exit")
 let changed=contents(directory).filter{ $0.value==Data(("new-"+$0.key).utf8)}.count
 let expectedChanged=stage=="prepared" ? 0:stage=="committed" ? 3:Int(stage.suffix(1))!
 check(changed==expectedChanged,"\(stage) reproduces the intended partially replaced files")
 let outcome=try ManualRecordTransaction.recover(in:directory)
 let expectedOutcome:ManualRecoveryOutcome=stage=="committed" ? .committed:.rolledBack
 check(outcome==expectedOutcome,"\(stage) distinguishes prepared rollback from committed completion")
 let after=contents(directory)
 check(stage=="committed" ? after==Dictionary(uniqueKeysWithValues:payload(directory).map{($0.key.lastPathComponent,$0.value)}):after==before,"\(stage) resolves the whole store set to one coherent version")
 check(!FileManager.default.fileExists(atPath:journal.path),"\(stage) removes recovery journal only after consistency")
 let report=ManualRecordTransaction.lastRecovery(in:directory)
 check(report?.outcome==expectedOutcome && report?.files==3 && report?.cleanupPending==false,"\(stage) records inspectable completion or rollback result")
 let again=try ManualRecordTransaction.recover(in:directory)
 check(again == .none && contents(directory)==after,"\(stage) repeated recovery is idempotent")
 scenarios.append(["checkpoint":stage,"childExit":97,"partiallyChangedFiles":changed,"outcome":outcome.rawValue,"coherent":true])
}
for interruptedAt in [1,3] {
 let directory=folder("rollback-interruption-\(interruptedAt)");try prepare(directory);let original=contents(directory)
 try child("write-3",directory)
 let restarted=Process();restarted.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);restarted.arguments=["--rollback-kill",String(interruptedAt),directory.path]
 try restarted.run();restarted.waitUntilExit()
 check(restarted.terminationStatus==97,"recovery process actually exits after rollback file \(interruptedAt)")
 let oldCount=contents(directory).filter{$0.value==Data(("old-"+$0.key).utf8)}.count
 check(oldCount==interruptedAt && FileManager.default.fileExists(atPath:directory.appendingPathComponent("manual-restore-journal-v1.json").path),"interrupted rollback retains the journal until all original files are safe")
 let resumed=try ManualRecordTransaction.recover(in:directory)
 check(resumed == .rolledBack && contents(directory)==original,"a second startup completes interrupted rollback idempotently")
}
let missing=folder("missing-original");try prepare(missing,missing:"integrated-v1.json");let missingBefore=contents(missing)
try child("write-3",missing);_ = try ManualRecordTransaction.recover(in:missing)
check(contents(missing)==missingBefore,"rollback removes a newly created store when original did not exist")
let normal=folder("normal");try prepare(normal)
try ManualRecordTransaction.commit(payload(normal))
check(contents(normal).allSatisfy{$0.value==Data(("new-"+$0.key).utf8)},"normal transaction commits all three stores")
let report=ManualRecordTransaction.lastRecovery(in:normal)
check(report?.outcome == .committed,"normal success creates a persistent verification report")
let fail=folder("caught-error");try prepare(fail);let failBefore=contents(fail)
check(throwsError{try ManualRecordTransaction.commit(payload(fail),failAfter:1)},"caught write failure is not reported as success")
check(contents(fail)==failBefore && ManualRecordTransaction.lastRecovery(in:fail)?.outcome == .rolledBack,"caught write failure uses the same durable rollback contract")
let reader=folder("reader-trigger");try prepare(reader);let readerBefore=contents(reader);try child("write-2",reader)
let restoredByRead=try ManualRecordTransaction.read(from:reader.appendingPathComponent("events-v1.json"))
check(restoredByRead==readerBefore["events-v1.json"] && contents(reader)==readerBefore,"first manual-store read recovers before exposing a partially restored record")
let writer=folder("writer-trigger");try prepare(writer);try child("write-1",writer)
try ManualRecordTransaction.write(Data("deliberate-update".utf8),to:writer.appendingPathComponent("events-v1.json"))
check(contents(writer)["events-v1.json"]==Data("deliberate-update".utf8) && contents(writer)["integrated-v1.json"]==Data("old-integrated-v1.json".utf8),"normal writer first rolls back pending restore, then applies one atomic update")
let empty=folder("empty");try FileManager.default.createDirectory(at:empty,withIntermediateDirectories:true)
let unread=try ManualRecordTransaction.read(from:empty.appendingPathComponent("events-v1.json"))
check(unread==nil,"missing manual record stays missing rather than an invented zero-length JSON store")
try ManualRecordTransaction.write(Data(),to:empty.appendingPathComponent("events-v1.json"))
let zero=try ManualRecordTransaction.read(from:empty.appendingPathComponent("events-v1.json"))
check(zero != nil && zero!.isEmpty,"existing empty bytes stay distinct from a missing file")
func corrupt(_ name:String,_ mutate:(inout [String:Any])->Void)throws->(URL,[String:Data]) {
 let directory=folder(name);try prepare(directory);try child("write-1",directory)
 let url=directory.appendingPathComponent("manual-restore-journal-v1.json")
 var object=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any];mutate(&object)
 try JSONSerialization.data(withJSONObject:object,options:.sortedKeys).write(to:url)
 return(directory,contents(directory))
}
let unknown=try corrupt("unknown-schema",{$0["version"]=99})
check(throwsError{_ = try ManualRecordTransaction.recover(in:unknown.0)} && contents(unknown.0)==unknown.1,"unknown journal schema blocks before any rollback mutation")
check(throwsError{try ManualRecordTransaction.write(Data("bad-write".utf8),to:unknown.0.appendingPathComponent("events-v1.json"))},"a corrupt pending journal blocks normal writer too")
check(throwsError{_ = try ManualRecordTransaction.read(from:unknown.0.appendingPathComponent("events-v1.json"))},"a corrupt pending journal cannot expose a partial manual-store read")
check(FileManager.default.fileExists(atPath:unknown.0.appendingPathComponent("manual-restore-journal-v1.json").path),"unverifiable recovery originals are retained for diagnosis")
let checksum=try corrupt("bad-checksum",{object in var rows=object["entries"] as! [[String:Any]];rows[1]["original"]=Data("altered".utf8).base64EncodedString();object["entries"]=rows})
check(throwsError{_ = try ManualRecordTransaction.recover(in:checksum.0)} && contents(checksum.0)==checksum.1,"original checksum corruption is detected before first rollback write")
let traversal=try corrupt("path-traversal",{object in var rows=object["entries"] as! [[String:Any]];rows[0]["name"]="../outside.json";object["entries"]=rows})
check(throwsError{_ = try ManualRecordTransaction.recover(in:traversal.0)} && contents(traversal.0)==traversal.1,"journal names cannot escape the allowlisted manual stores")
let duplicate=try corrupt("duplicate-entry",{object in var rows=object["entries"] as! [[String:Any]];rows[1]=rows[0];object["entries"]=rows})
check(throwsError{_ = try ManualRecordTransaction.recover(in:duplicate.0)} && contents(duplicate.0)==duplicate.1,"duplicate recovery entries cannot overwrite a store twice")
let committed=folder("committed-corrupt");try prepare(committed);try child("committed",committed)
try Data("disk-corruption".utf8).write(to:committed.appendingPathComponent("events-v1.json"));let corruptedContents=contents(committed)
check(throwsError{_ = try ManualRecordTransaction.recover(in:committed)} && contents(committed)==corruptedContents,"committed checksum mismatch preserves both records and recovery snapshots instead of guessing")
let unsafe=folder("unsafe-payload");try prepare(unsafe);let unsafeBefore=contents(unsafe)
check(throwsError{try ManualRecordTransaction.commit([unsafe.appendingPathComponent("other.json"):Data("bad".utf8)])} && contents(unsafe)==unsafeBefore,"unknown payload filenames cannot enter restore transaction")
let other=folder("other-directory");try prepare(other)
check(throwsError{try ManualRecordTransaction.commit([unsafe.appendingPathComponent("events-v1.json"):Data("bad".utf8),other.appendingPathComponent("integrated-v1.json"):Data("bad".utf8)])},"one transaction cannot silently span separate directories")
let external=root.appendingPathComponent("outside-marker");try Data("preserve".utf8).write(to:external)
let links=folder("symlink-target");try FileManager.default.createDirectory(at:links,withIntermediateDirectories:true)
try FileManager.default.createSymbolicLink(at:links.appendingPathComponent("events-v1.json"),withDestinationURL:external)
check(throwsError{try ManualRecordTransaction.write(Data("bad".utf8),to:links.appendingPathComponent("events-v1.json"))},"symlink destinations are rejected before writing")
let externalData=try Data(contentsOf:external)
check(externalData==Data("preserve".utf8),"symlink rejection leaves outside target untouched")
let dangling=folder("dangling-link");try FileManager.default.createDirectory(at:dangling,withIntermediateDirectories:true)
try FileManager.default.createSymbolicLink(at:dangling.appendingPathComponent("events-v1.json"),withDestinationURL:root.appendingPathComponent("nonexistent"))
check(throwsError{try ManualRecordTransaction.write(Data("bad".utf8),to:dangling.appendingPathComponent("events-v1.json"))},"dangling symlinks are not mistaken for safe missing files")
let busy=folder("busy");try prepare(busy);let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);process.arguments=["--hold",busy.path];process.standardOutput=pipe;try process.run()
let ready=pipe.fileHandleForReading.readData(ofLength:7)
check(ready==Data("locked\n".utf8),"separate process holds the real filesystem lock")
let timer=Date()
check(throwsError{_ = try ManualRecordTransaction.recover(in:busy)},"recovery refuses a concurrent active writer")
check(throwsError{try ManualRecordTransaction.write(Data("bad".utf8),to:busy.appendingPathComponent("events-v1.json"))},"normal write cannot race an active restore lock")
check(throwsError{_ = try ManualRecordTransaction.read(from:busy.appendingPathComponent("events-v1.json"))},"read cannot observe a transaction while another process holds the lock")
check(Date().timeIntervalSince(timer)<1,"busy lock is nonblocking and cannot freeze the interface waiting for a writer")
try Data().write(to:busy.appendingPathComponent("release"));process.waitUntilExit();check(process.terminationStatus==0,"lock holder releases cleanly")
let unlocked=try ManualRecordTransaction.read(from:busy.appendingPathComponent("events-v1.json"))
check(unlocked==Data("old-events-v1.json".utf8),"manual read resumes after lock release")
let large=Data(repeating:0,count:33*1024*1024)
check(throwsError{try ManualRecordTransaction.write(large,to:unsafe.appendingPathComponent("events-v1.json"))} && contents(unsafe)==unsafeBefore,"oversized normal write is rejected without altering old records")
check(throwsError{try ManualRecordTransaction.commit([unsafe.appendingPathComponent("events-v1.json"):large])} && contents(unsafe)==unsafeBefore,"oversized restoration is rejected before journal mutation")
let oversizedReader=folder("oversized-existing");try FileManager.default.createDirectory(at:oversizedReader,withIntermediateDirectories:true)
try large.write(to:oversizedReader.appendingPathComponent("events-v1.json"))
check(throwsError{_ = try ManualRecordTransaction.read(from:oversizedReader.appendingPathComponent("events-v1.json"))},"oversized existing store is read with a bounded buffer and preserved")
let preservedSize=try FileManager.default.attributesOfItem(atPath:oversizedReader.appendingPathComponent("events-v1.json").path)[.size] as! NSNumber
check(preservedSize.intValue==large.count,"bounded-read rejection does not truncate or replace the oversized record")
check(throwsError{_ = try ManualRecordTransaction.readBackup(from:oversizedReader.appendingPathComponent("events-v1.json"))},"selected backup import is bounded before decoding, not after an unbounded file load")
let largeEvents=(0..<9000).map{_ in PocketEvent(date:Date().addingTimeInterval(-60),kind:"自评",energy:3,note:String(repeating:"x",count:1000))}
let bigBackup=PocketBackup(createdAt:Date(),demo:true,events:largeEvents,records:IntegratedRecords(),manualEnergy:[])
check(bigBackup.valid(now:Date()),"large synthetic backup fixture satisfies domain rules before size rejection")
check(throwsError{_ = try PocketBackupIO.encoded(bigBackup)},"export cannot create a backup larger than the import contract can read")
if CommandLine.arguments.count>1 {
 let object:[String:Any]=["syntheticOnly":true,"childProcessExitTested":true,"devicePowerLossTested":false,"checkpoints":scenarios,"rollbackInterruptionAtFiles":[1,3],"checks":checks,"sourceStores":names]
 try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
}
print("\(checks) durable restore checks passed; real child-process exits over synthetic local files, not physical-device power-loss verification")
