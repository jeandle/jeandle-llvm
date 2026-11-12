#!/usr/bin/env python3
"""Run the ten frozen JavaType workloads on configurable Jeandle builds (Linux)."""
import argparse, os, json, subprocess, resource, time, statistics as st, random, hashlib, shutil
from pathlib import Path
ROOT = Path(__file__).resolve().parent
SCENARIOS = ['same', 'cross-unique', 'cross', 'same-edit', 'other-edit']
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--versions', type=Path, required=True)
p.add_argument('--cpu', type=int, required=True)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--repeats', type=int, default=31)
p.add_argument('--aa-repeats', type=int, default=15)
p.add_argument('--warmups', type=int, default=3)
p.add_argument('--seed', type=int, default=20261103)
args = p.parse_args()
if __import__('sys').flags.optimize:
 p.error('Python optimization disables required correctness checks')
if args.repeats < 5 or args.aa_repeats < 5 or args.warmups < 0:
 p.error('require at least five comparison/A-A rounds and nonnegative warmups')
if not hasattr(os, 'sched_getaffinity'):
 p.error('timing requires Linux CPU affinity support')
if args.cpu not in os.sched_getaffinity(0):
 p.error('CPU is outside allowed affinity')
versions = json.loads(args.versions.read_text())
if 'base' not in versions or len(versions) < 2:
 p.error('versions must include base and at least one comparison build')
for v, cfg in versions.items():
 if not v.replace('-', '').replace('_', '').isalnum():
  p.error('version names must contain only letters, digits, underscores or hyphens')
 for key in ('opt', 'replay'):
  path = Path(cfg[key]).expanduser()
  if not path.is_absolute() or not path.is_file():
   p.error(f'{v}.{key} must be an existing absolute file path')
  cfg[key] = str(path.resolve())
 cfg.setdefault('opt_flags', [])
 if not isinstance(cfg['opt_flags'], list) or any(not isinstance(f, str) or any(t in f for t in ('stats', 'verify', 'print<', 'debug', 'time-passes')) for f in cfg['opt_flags']):
  p.error('opt_flags must be a list without observer or verification flags')
os.environ.pop('LD_LIBRARY_PATH', None)
os.sched_setaffinity(0, {args.cpu})
opts = {v: Path(c['opt']) for v, c in versions.items()}
casefile = ROOT / 'inputs/opt-inputs/cases.json'
if not casefile.exists():
 p.error('run prepare.py first')
optcases = json.loads(casefile.read_text())
for c in optcases:
 for key in ('input', 'callback'):
  c[key] = str((casefile.parent / c[key]).resolve())

def interval(values, seed):
 rng = random.Random(seed)
 estimates = sorted(st.median(rng.choices(values, k=len(values))) for _ in range(4000))
 return [estimates[100], estimates[3899]]

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
out=args.out.resolve();out.mkdir(parents=True,exist_ok=False);raw=(out/'samples.jsonl').open('w',buffering=1);rng=random.Random(args.seed)
work = out / 'native'
work.mkdir()
for v in versions:
 (work/v).mkdir()
 for name in SCENARIOS:
  shutil.copyfile(ROOT/'inputs'/f'{name}.ll', work/v/f'{name}.ll')
inputs = json.loads((ROOT/'inputs/SHA256.json').read_text())
for name, expected in inputs.items():
 if sha(ROOT/'inputs'/name) != expected:
  raise RuntimeError('frozen input changed: '+name)
manifest = {
 'versions': {v: dict(cfg, opt_sha256=sha(cfg['opt']), replay_sha256=sha(cfg['replay'])) for v, cfg in versions.items()},
 'affinity': list(os.sched_getaffinity(0)), 'aa_repeats': args.aa_repeats,
 'repeats': args.repeats, 'warmups': args.warmups, 'seed': args.seed,
 'input_hashes': {}, 'batches': {}, 'runner_sha256': sha(__file__),
 'frozen_inputs': inputs, 'cases': optcases,
 'native_source_hashes': {f.name:sha(f) for f in (ROOT/'native').iterdir() if f.is_file()},
}
for name in ('topology/thread_siblings_list', 'cpufreq/scaling_governor'):
 path = Path(f'/sys/devices/system/cpu/cpu{args.cpu}')/name
 manifest[name] = path.read_text().strip() if path.exists() else None
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
summary=[];diags={};scenarios=SCENARIOS
def execute_native(s,v,n,kind='timing'):
 p=subprocess.run([str(versions[v]['replay']),s,'cached',str(n),kind],capture_output=True,text=True,timeout=120,cwd=work/v)
 if p.returncode:raise RuntimeError(p.stderr)
 a=json.loads(p.stdout);assert a['queries']==32*n and a['checksum']==22*32*n
 return a

def execute_opt(c,v,phase='timing'):
 diagnostic=phase=='diagnostic';verify=phase=='verification';cmd=[str(opts[v]),'-S' if diagnostic or verify else '-disable-output','-passes='+c['passes']+(',print<java-type-analysis-summary>' if diagnostic else ''),'-jeandle-vm-callback-log='+c['callback'],c['input']]
 cmd += versions[v]['opt_flags']
 if diagnostic:cmd+=['-jeandle-java-type-stats=true','-verify-each']
 if verify:cmd+=['-jeandle-verify-java-type-cache=true','-verify-each']
 before=resource.getrusage(resource.RUSAGE_CHILDREN);t=time.perf_counter();p=subprocess.run(cmd,capture_output=True,timeout=120);after=resource.getrusage(resource.RUSAGE_CHILDREN)
 if p.returncode:raise RuntimeError(p.stderr.decode())
 if phase!='timing':
  (out/(c['name']+'-'+v+'-'+phase+'.stderr')).write_bytes(p.stderr)
  (out/(c['name']+'-'+v+'-'+phase+'.ll')).write_bytes(p.stdout)
 elif p.stdout:raise RuntimeError('unexpected timing output')
 return {'cpu_s':after.ru_utime+after.ru_stime-before.ru_utime-before.ru_stime,'wall_s':time.perf_counter()-t,'command':cmd},p.stdout

for kind,cases in [('native',scenarios),('opt',optcases)]:
 for c in cases:
  name=c if kind=='native' else c['name'];batches={}
  if kind=='native':
   for v in versions:
    a=execute_native(c,v,2,'diagnostic');diags[name+':'+v]=a
    n=4
    while True:
     a=execute_native(c,v,n)
     if a['cpu_s']>=.12:break
     n*=4
    batches[v]=max(n,int(n*.36/a['cpu_s'])+1)
   manifest['input_hashes'][name]=sha(ROOT/'inputs'/f'{name}.ll');manifest['batches'][name]=batches
   for v in versions:
    assert sha(work/v/f'{name}.ll')==manifest['input_hashes'][name], 'native input differs: '+v+':'+name
  else:
   ir=[]
   for v in versions:
    _,verified=execute_opt(c,v,'verification');a,diagnosed=execute_opt(c,v,'diagnostic')
    assert verified==diagnosed,'verification changed IR'
    ir.append(diagnosed)
   assert all(x==ir[0] for x in ir),'cross-version IR differs: '+name
   manifest['input_hashes'][name]={'ir':sha(c['input']),'callback':sha(c['callback'])}
  (out/'diagnostics.json').write_text(json.dumps(diags,indent=2));print('prepared',kind,name,flush=True)
  def measure(v):
   if kind=='native':
    a=execute_native(c,v,batches[v]);a['cost']=a['cpu_s']/batches[v];a['batches']=batches[v]
   else:
    a,_=execute_opt(c,v);a['cost']=a['cpu_s']
   return a
  aa=[];aa_durations=[]
  for i in range(args.warmups+args.aa_repeats):
   arms=['a','b'];rng.shuffle(arms);pair={}
   for arm in arms:
    a=measure('base');pair[arm]=a;raw.write(json.dumps(dict(a,phase='aa',kind=kind,case=name,version='base',arm=arm,round=i,warmup=i<args.warmups))+'\n')
   if i>=args.warmups:aa.append(100*(pair['b']['cost']/pair['a']['cost']-1));aa_durations.extend(x['cpu_s'] for x in pair.values())
  floor=sorted(abs(x) for x in aa)[int(.95*(len(aa)-1))];pairs=[]
  for i in range(args.warmups+args.repeats):
   order=list(versions);rng.shuffle(order);pair={}
   for v in order:
    a=measure(v);pair[v]=a;raw.write(json.dumps(dict(a,phase='comparison',kind=kind,case=name,version=v,round=i,warmup=i<args.warmups))+'\n')
   if i>=args.warmups:pairs.append(pair)
  entry={'kind':kind,'case':name,'metric':'CPU ms / 32-query batch' if kind=='native' else 'opt process CPU ms','aa_noise_p95':floor,'min_cpu_s':min([x['cpu_s'] for p in pairs for x in p.values()]+aa_durations),'cost_ms':{v:st.median(p[v]['cost'] for p in pairs)*1000 for v in versions},'comparisons':{}}
  for left,right in __import__('itertools').combinations(versions,2):
   d=[100*(p[right]['cost']/p[left]['cost']-1) for p in pairs];ci=interval(d,args.seed);verdict='inconclusive'
   if entry['min_cpu_s']>=.2:
    if ci[1]<-floor:verdict='improvement'
    elif ci[0]>floor:verdict='regression'
   entry['comparisons'][left+'->'+right]={'change_pct':st.median(d),'ci95':ci,'verdict':verdict}
  summary.append(entry);(out/'summary.json').write_text(json.dumps(summary,indent=2));(out/'manifest.json').write_text(json.dumps(manifest,indent=2));print(json.dumps(entry),flush=True)
for v in versions:
 assert manifest['versions'][v]['opt_sha256']==sha(opts[v]) and manifest['versions'][v]['replay_sha256']==sha(versions[v]['replay'])
for c in optcases:
 assert manifest['input_hashes'][c['name']]=={'ir':sha(c['input']), 'callback':sha(c['callback'])}
for name, expected in inputs.items():
 assert sha(ROOT/'inputs'/name)==expected
assert manifest['runner_sha256']==sha(__file__)
(out/'SUCCESS').write_text('complete\n')
