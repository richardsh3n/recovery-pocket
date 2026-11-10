#!/usr/bin/env python3
"""Compile the unchanged core once, then run the same test programs with @testable access.
No device installation, account access, real HealthKit reads, or network requests.
"""
from pathlib import Path
import argparse, concurrent.futures, hashlib, json, os, re, subprocess, sys
ROOT = Path(__file__).resolve().parents[1]
COMMON = ['Shared/BatteryModel.swift','RecoveryPocket/RecoveryEngine.swift','RecoveryPocket/RecoveryModelV2.swift','RecoveryPocket/CoachCore.swift','RecoveryPocket/DecisionCore.swift','RecoveryPocket/EnergyInsightsCore.swift','RecoveryPocket/WellnessCore.swift','RecoveryPocket/EnergyBudgetCore.swift','RecoveryPocket/IntegratedCore.swift']
SUITES = {'core':'CoreTests','calibration':'RecoveryCalibrationTests','continuous':'ContinuousBatteryTests','algorithm':'AlgorithmTests','state':'CurrentStateTests','widget':'WidgetTests','coach':'CoachTests','insights':'InsightTests','wellness':'WellnessTests','audit':'AuditTests','performance':'PerformanceTests','iteration':'IterationTests','intensity':'IntensityResponseTests','integrated':'IntegratedTests','energy':'EnergyBudgetTests','shadow':'ShadowComparisonTests','restore':'RestoreDurabilityTests','backup':'BackupHistoryTests','validity':'AlgorithmValidityTests','eligibility':'ShadowEligibilityTests','cache':'StateCacheTests','grid':'ActivityGridTests','meaning':'ScoreMeaningTests'}
PROOFS = {'iteration':'iteration-proof.json','intensity':'sensitivity-proof.json','calibration':'recovery-scenarios.json','integrated':'training-candidate-grid.json','shadow':'shadow-proof.json','restore':'restore-proof.json','backup':'backup-proof.json','validity':'algorithm-validity-proof.json','eligibility':'eligibility-proof.json','cache':'state-cache-proof.json','grid':'activity-grid-proof.json','meaning':'score-meaning-proof.json'}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,default=ROOT/'build/verification')
parser.add_argument('--only',nargs='+',choices=SUITES.keys())
parser.add_argument('--jobs',type=int,default=2)
args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env['NSUnbufferedIO']='YES'
if not env.get('DEVELOPER_DIR') and Path('/Applications/Xcode.app/Contents/Developer').exists():env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def source_hashes():return {p:sha(ROOT/p) for p in COMMON}
source=source_hashes()
compiler=subprocess.run(['/usr/bin/xcrun','swiftc','--version'],capture_output=True,text=True,env=env,check=True).stdout.strip()
key=hashlib.sha256(json.dumps({'source':source,'compiler':compiler,'flags':['-O','-enable-testing']},sort_keys=True).encode()).hexdigest()
cache=out/'modules'/key;cache.mkdir(parents=True,exist_ok=True)
library=cache/'libPocketCoreChecks.dylib';module=cache/'PocketCoreChecks.swiftmodule'
if not library.exists() or not module.exists():
    command=['/usr/bin/xcrun','swiftc','-O','-enable-testing','-emit-library','-emit-module','-module-name','PocketCoreChecks','-emit-module-path',str(module),*[str(ROOT/p) for p in COMMON],'-Xlinker','-install_name','-Xlinker','@rpath/libPocketCoreChecks.dylib','-o',str(library)]
    with (out/'module-build.log').open('w') as stream:
        result=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,env=env)
    if result.returncode or source_hashes()!=source:
        sys.exit('Core compilation failed or sources changed during compilation; inspect module-build.log. No success recorded.')
(cache/'source.json').write_text(json.dumps({'sourceSHA256':source,'compiler':compiler,'key':key},indent=2)+'\n')
def run(name):
    origin=ROOT/SUITES[name]/'main.swift';origin_hash=sha(origin)
    folder=out/name;folder.mkdir(parents=True,exist_ok=True)
    main=folder/'main.swift';main.write_text('@testable import PocketCoreChecks\n'+origin.read_text())
    binary=folder/'checks';log=folder/'checks.log'
    command=['/usr/bin/xcrun','swiftc','-O','-I',str(cache),'-L',str(cache),'-lPocketCoreChecks','-Xlinker','-rpath','-Xlinker',str(cache),str(main),'-o',str(binary)]
    with log.open('w') as stream:
        compiled=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,env=env)
        if compiled.returncode or sha(origin)!=origin_hash:return {'suite':name,'passed':False,'phase':'compile-or-source-change'}
        invocation=[str(binary)]
        if name in PROOFS:invocation.append(str(out/PROOFS[name]))
        tested=subprocess.run(invocation,stdout=stream,stderr=subprocess.STDOUT,env=env)
    lines=log.read_text().splitlines();count=sum(x.startswith('PASS:') for x in lines)
    if not count:
        matching=[re.match(r'(\d+).*checks',x) for x in lines]
        count=next((int(x[1]) for x in reversed(matching) if x),0)
    return {'suite':name,'passed':tested.returncode==0 and source_hashes()==source and sha(origin)==origin_hash,'assertions':count,'lastLine':lines[-1] if lines else '', 'testSourceSHA256':origin_hash}
selected=args.only or list(SUITES)
with concurrent.futures.ThreadPoolExecutor(max_workers=max(1,min(4,args.jobs))) as pool:
    results=list(pool.map(run,selected))
previous=out/'test-results.json'
if args.only and previous.exists():
    old=json.loads(previous.read_text())
    if old.get('coreKey')==key:results=[x for x in old.get('suites',[]) if x['suite'] not in selected]+results
report={'compiler':compiler,'runner':'single compiled core with testable access','coreKey':key,'coreSourceSHA256':source,'allPassed':all(x['passed'] for x in results),'assertions':sum(x.get('assertions',0) for x in results if x['passed']),'suites':results}
previous.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
for row in results:print(json.dumps(row,ensure_ascii=False),flush=True)
print(json.dumps({'allPassed':report['allPassed'],'suites':len(results),'assertions':report['assertions']},ensure_ascii=False),flush=True)
sys.exit(0 if report['allPassed'] else 1)
