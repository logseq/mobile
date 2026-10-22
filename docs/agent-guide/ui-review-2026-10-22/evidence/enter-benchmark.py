"""Measure the installed Android app on the dedicated emulator fixture.

Run after installing the intended before/after APK and its test APK. Only the
UI Regression graph on emulator-5556 is touched; its SQLite backup is restored
in finally. The ignored artifact folder retains raw measurements and fixture.
"""
import subprocess,sqlite3,shutil,tempfile,sys,json,hashlib
from pathlib import Path
label=sys.argv[1]
assert label in ['before','after']
mode=sys.argv[2] if len(sys.argv)>2 else 'key'
assert mode in ['key','ime']
name=label if mode=='key' else label+'-'+mode
serial='emulator-5556';app='com.logseq.app'
base=Path(__file__).resolve().parents[4]
evidence=base/'docs/agent-guide/ui-review-2026-10-22/evidence/enter-performance-artifacts'
evidence.mkdir(parents=True,exist_ok=True)
(evidence/(name+'.json')).unlink(missing_ok=True)
tmp=Path(tempfile.mkdtemp(prefix='logseq-enter-'))
graph='files/graphs/UI_Regression-uiregression/graph.sqlite'
def run(*args,**kw):return subprocess.run(['rtk','proxy',*map(str,args)],check=True,**kw)
def adb(*args,**kw):return run('adb','-s',serial,*args,**kw)
prefs=adb('exec-out','run-as',app,'cat','shared_prefs/logseq.xml',capture_output=True).stdout
assert b'>uiregression<' in prefs
adb('shell','am','force-stop',app)
for suffix in ['', '-wal','-shm']:
    r=subprocess.run(['rtk','proxy','adb','-s',serial,'exec-out','run-as',app,'cat',graph+suffix],capture_output=True)
    if r.returncode==0:(tmp/('source.sqlite'+suffix)).write_bytes(r.stdout)
with sqlite3.connect(tmp/'source.sqlite') as source,sqlite3.connect(tmp/'original.sqlite') as target:source.backup(target)
fixture=evidence/'fixture-500.sqlite'
if label=='before':
    shutil.copy2(tmp/'original.sqlite',fixture)
    with sqlite3.connect(fixture) as db:
        tables={r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        for table in ['logseq_pending_op_dependencies','logseq_pending_txs','logseq_pending_ops','logseq_sync_state']:
            if table in tables:db.execute('DELETE FROM '+table)
    result=run(base/'_build/default/shared/native/logseq_e2e_seed.exe',fixture,'--performance=1x500',capture_output=True,text=True)
    (evidence/'seed.log').write_text(result.stdout+result.stderr)
assert fixture.exists()
def install(file):
    adb('push',file,'/data/local/tmp/logseq-enter-fixture.sqlite',capture_output=True)
    adb('shell','run-as',app,'rm','-f',graph+'-wal',graph+'-shm')
    adb('shell','run-as',app,'cp','/data/local/tmp/logseq-enter-fixture.sqlite',graph)
try:
    install(fixture)
    adb('shell','run-as',app,'rm','-f','files/enter-benchmark-500-'+label+'-'+mode+'.json')
    r=adb('shell','am','instrument','-w','-r','-e','verifyEnterPerformance','true','-e','enterFixtureBlocks','500','-e','benchmarkLabel',label,'-e','enterInputMode',mode,'-e','class','com.logseq.app.AndroidEnterPerformanceTest',app+'.test/androidx.test.runner.AndroidJUnitRunner',capture_output=True,text=True)
    (evidence/(name+'.log')).write_text(r.stdout+r.stderr)
    for artifact in ['enter-failure.png','enter-failure.txt']:
        failure=subprocess.run(['rtk','proxy','adb','-s',serial,'exec-out','run-as',app,'cat','files/'+artifact],capture_output=True)
        if failure.returncode==0 and not failure.stdout.startswith(b'cat:') and (artifact.endswith('.txt') or failure.stdout.startswith(bytes([137,80,78,71]))):(evidence/artifact).write_bytes(failure.stdout)
    print((r.stdout+r.stderr)[-3500:],flush=True)
    stats=subprocess.run(['rtk','proxy','adb','-s',serial,'exec-out','run-as',app,'cat','files/enter-benchmark-500-'+label+'-'+mode+'.json'],capture_output=True)
    if stats.returncode==0 and stats.stdout.lstrip().startswith(b'{'):
        data=json.loads(stats.stdout);data['fixture_sha256']=hashlib.sha256(fixture.read_bytes()).hexdigest()
        (evidence/(name+'.json')).write_text(json.dumps(data,indent=2)+'\n')
    adb('shell','am','force-stop',app)
    for suffix in ['', '-wal','-shm']:
        captured=subprocess.run(['rtk','proxy','adb','-s',serial,'exec-out','run-as',app,'cat',graph+suffix],capture_output=True)
        if captured.returncode==0:(tmp/('result.sqlite'+suffix)).write_bytes(captured.stdout)
    with sqlite3.connect(tmp/'result.sqlite') as db:
        operations=[json.loads(row[0]) for row in db.execute('select intent from logseq_pending_ops')]
    (evidence/(name+'-operations.json')).write_text(json.dumps(operations,indent=2)+'\n')
    print('Persisted pending operations:', len(operations),flush=True)
    splits=[op for op in operations if op.get('type')=='split-block']
    assert len(splits)==35, f'Each Enter must persist: expected 35 splits, got {len(splits)}'
    assert len({op['newUuid'] for op in splits})==35
    assert all(op['before']=='' and op['after']==splits[0]['after'] for op in splits)
    assert all(splits[i]['uuid']==splits[i-1]['newUuid'] for i in range(1,len(splits)))
    if (evidence/(name+'.json')).exists():
        data=json.loads((evidence/(name+'.json')).read_text())
        data['persisted_splits']=len(splits)
        data['apk_sha256']=hashlib.sha256((base/'android/app/build/outputs/apk/debug/app-debug.apk').read_bytes()).hexdigest()
        (evidence/(name+'.json')).write_text(json.dumps(data,indent=2)+'\n')
    assert 'OK (1 test)' in r.stdout, 'Installed-app latency/identity test failed; see '+str(evidence/(name+'.log'))
finally:
    adb('shell','am','force-stop',app)
    install(tmp/'original.sqlite')
    print('Restored dedicated QA graph from',tmp,flush=True)
