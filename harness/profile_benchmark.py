"""Attested, bounded profile captures on an explicitly controlled ShaderBench game.

This tool MOVES THE CAMERA and switches the requested pack. Run only while owning
the runtime lane. PresentMon, not BenchCam's CPU counter, supplies frame timings.
"""
from __future__ import annotations

import argparse
import collections
import ctypes
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import time
import uuid
import zipfile

from bench import Bench
from perf_capture import (attest_pack_artifact, build_presentmon_command,
                          parse_benchcam_status, validate_capture_csv)

GAME = Path(os.environ['APPDATA']) / 'PrismLauncher/instances/ShaderBench/minecraft'
SCENES = {
    'night': (-738.03, 110, -276.22, 175, -15, 162000),
    'landscape': (-778, 140, -283, 0, 10, 150000),
    'water': (1014, 72, -283, 45, 12, 149000),
    'cave': (2615, -36, 615, 180, 0, 150000),
    'above_cloud': (-778, 800, -283, 0, 10, 150000),
}


def dump(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf8')


def props(path):
    return {k.strip(): v.strip() for line in path.read_text(encoding='utf-8-sig').splitlines()
            if not line.startswith('#') and '=' in line
            for k, v in [line.split('=', 1)]}


def snapshot(pid):
    script = (f'$p=Get-CimInstance Win32_Process -Filter "ProcessId={pid}";'
              '$m=Get-CimInstance Win32_OperatingSystem;'
              '[pscustomobject]@{pid=$p.ProcessId;name=$p.Name;exe=$p.ExecutablePath;'
              "session_id=$p.SessionId;matches_instance=([string]$p.CommandLine).Replace('/','\\').Contains('PrismLauncher\\instances\\ShaderBench');"
              'private_bytes=$p.PrivatePageCount;working_set_bytes=$p.WorkingSetSize;'
              'free_ram_kib=$m.FreePhysicalMemory;total_ram_kib=$m.TotalVisibleMemorySize;'
              'free_commit_kib=$m.FreeVirtualMemory;total_commit_kib=$m.TotalVirtualMemorySize}'
              '|ConvertTo-Json -Compress')
    mem = json.loads(subprocess.check_output(['powershell', '-NoProfile', '-Command', script], text=True))
    gpu = subprocess.check_output(['nvidia-smi', '--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,clocks.current.graphics', '--format=csv,noheader'], text=True).strip()
    return {'memory': mem, 'nvidia_smi': gpu, 'utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}


def percentiles(values):
    values = sorted(values)
    def q(p):
        n = (len(values) - 1) * p
        lo, hi = math.floor(n), math.ceil(n)
        return values[lo] + (values[hi] - values[lo]) * (n - lo)
    return {'n': len(values), 'p50_ms': q(.5), 'p95_ms': q(.95), 'p99_ms': q(.99)}


def profile_options(artifact, profile):
    """Read the real Iris profile definition, rather than duplicate preset values."""
    if artifact.is_dir():
        text = (artifact/'shaders/shaders.properties').read_text(encoding='utf-8-sig')
    else:
        with zipfile.ZipFile(artifact) as archive:
            names = [n for n in archive.namelist() if n.endswith('shaders/shaders.properties')]
            if len(names) != 1: raise RuntimeError('Ambiguous shader properties in archive')
            text = archive.read(names[0]).decode('utf-8-sig')
    prefix = f'profile.{profile}='
    lines = [line for line in text.splitlines() if line.startswith(prefix)]
    if len(lines) != 1: raise RuntimeError(f'Missing or ambiguous profile {profile}')
    result = {}
    for token in lines[0][len(prefix):].split():
        if '=' in token:
            key, value = token.split('=', 1)
        elif token.startswith('!'):
            key, value = token[1:], 'false'
        else:
            key, value = token, 'true'
        result[key] = value
    return result


def apply_options(output_dir, pack, options):
    """Preserve existing artistic controls, replacing only declared profile keys."""
    path = GAME/'shaderpacks'/f'{pack}.txt'
    backup = output_dir/f'{pack}.options-before.json'
    if not backup.exists():
        dump(backup, {'path':str(path), 'existed':path.exists(),
                      'text':path.read_text(encoding='utf-8-sig') if path.exists() else None})
    current = props(path) if path.exists() else {}
    current.update(options)
    temporary = path.with_name(path.name+f'.profilebench-{uuid.uuid4().hex}.tmp')
    temporary.write_text('# ShaderBench profile benchmark options\n' +
                         ''.join(f'{k}={v}\n' for k,v in sorted(current.items())), encoding='utf8')
    temporary.replace(path)


def analyze(path, pid, warmup):
    with path.open(encoding='utf-8-sig', newline='') as handle:
        rows = [r for r in csv.DictReader(handle) if int(r['ProcessID']) == pid]
    if not rows:
        raise RuntimeError('No target frames')
    counts = collections.Counter(r.get('SwapChainAddress') for r in rows)
    chain = counts.most_common(1)[0][0]
    rows = [r for r in rows if r.get('SwapChainAddress') == chain]
    def number(r, names):
        for key in names:
            try:
                n = float(r[key])
                if math.isfinite(n): return n
            except (KeyError, ValueError, TypeError): pass
        return None
    clock = ['CPUStartTime', 'CPUStartQPCTime', 'CPUStartTimeInMs', 'TimeInMs', 'TimeInSeconds']
    initial = number(rows[0], clock)
    timekey = next((k for k in clock if k in rows[0]), None)
    if initial is None or timekey is None:
        raise RuntimeError('Capture lacks timestamp needed to exclude warmup')
    scale = 1 if timekey == 'TimeInSeconds' else .001
    rows = [r for r in rows if (number(r, clock) - initial) * scale >= warmup]
    metrics = {}
    aliases = {'present': ['MsBetweenPresents', 'msBetweenPresents'],
               'gpu_busy': ['MsGPUBusy', 'msGPUActive'],
               'cpu_busy': ['MsCPUBusy', 'msCPUBusy'],
               'gpu_time': ['MsGPUTime']}
    for name, keys in aliases.items():
        values = [number(r, keys) for r in rows]
        values = [v for v in values if v is not None and v > 0]
        metrics[name] = percentiles(values) if values else {'n': 0, 'unavailable': True}
    metrics['swapchain'] = chain
    metrics['warmup_discarded_seconds'] = warmup
    return metrics


def capture(args, bench, spec, variant, index):
    runid = f'{args.scene}-{index:02d}-{variant}'
    output = args.output / f'{runid}.csv'
    if output.exists(): raise RuntimeError(f'Refusing overwrite: {output}')
    artifact = Path(spec['artifact'])
    requested_options = profile_options(artifact, spec['profile']) if spec.get('profile') else {}
    requested_options.update(spec.get('options', {}))
    if requested_options:
        apply_options(args.output, spec['pack'], requested_options)
    if spec.get('enabled', True):
        bench.send('pack ' + spec['pack'])
        bench.send('shaders on')
    else:
        bench.send('pack ' + spec['pack'])
        bench.send('shaders off')
    bench.send(f'wait {args.settle_ticks}')
    iris = props(GAME / 'config/iris.properties')
    if iris.get('shaderPack') != spec['pack']:
        raise RuntimeError('Iris selection differs from requested pack')
    if (iris.get('enableShaders') == 'true') != spec.get('enabled', True):
        raise RuntimeError('Iris enableShaders differs from requested state')
    packhash = attest_pack_artifact(GAME/'config/iris.properties', spec['pack'], artifact, spec.get('sha256'))
    log = (GAME/'logs/latest.log').read_text(encoding='utf8', errors='replace')
    renderers = [line for line in log.splitlines() if 'OpenGL Renderer:' in line]
    if not renderers or 'NVIDIA GeForce RTX 4070' not in renderers[-1]:
        raise RuntimeError('Verified RTX 4070 OpenGL renderer required before timing')
    pose = parse_benchcam_status(bench.send('status'))
    if 'screen=none' not in pose['status_reply']:
        raise RuntimeError('Game screen obstructs the scene')
    shot = args.output / f'{runid}.png'
    bench.send('shot ' + str(shot))
    from PIL import Image
    with Image.open(shot) as im: resolution = im.size
    settings = GAME/'shaderpacks'/f'{spec["pack"]}.txt'
    custom = settings.read_text(encoding='utf-8-sig') if settings.exists() else ''
    saved_options = props(settings) if settings.exists() else {}
    for name, value in requested_options.items():
        if saved_options.get(name) != str(value):
            raise RuntimeError(f'Requested option {name}={value} not persisted by Iris')
    before = snapshot(args.pid)
    session = f'profilebench-{args.pid}-{uuid.uuid4().hex}'
    command = build_presentmon_command(args.presentmon, args.pid, output, args.seconds, session)
    print(f'START {runid} {before["utc"]} {resolution} {packhash}', flush=True)
    cleanup = None
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=args.seconds+25)
    finally:
        # A killed CLI can leave ETW running. Terminate only this run's unique
        # session, never another user's PresentMon session.
        try:
            stopped = subprocess.run([str(args.presentmon),'--terminate_existing_session',
                                      '--session_name',session],capture_output=True,text=True,timeout=5)
            cleanup = {'returncode':stopped.returncode,'stdout':stopped.stdout,'stderr':stopped.stderr}
        except subprocess.TimeoutExpired:
            cleanup = {'timeout':True}
    if done.returncode: raise RuntimeError(done.stderr or done.stdout)
    frames = validate_capture_csv(output, args.pid)
    after = snapshot(args.pid)
    iris_after = props(GAME/'config/iris.properties')
    if iris != iris_after: raise RuntimeError('Iris settings changed during capture')
    if attest_pack_artifact(GAME/'config/iris.properties', spec['pack'], artifact) != packhash:
        raise RuntimeError('Shader artifact changed during capture')
    custom_after = settings.read_text(encoding='utf-8-sig') if settings.exists() else ''
    if custom != custom_after: raise RuntimeError('Shader options changed during capture')
    final_pose = parse_benchcam_status(bench.send('status'))
    if (pose['position'],pose['yaw'],pose['pitch'],pose['world_time']) != (final_pose['position'],final_pose['yaw'],final_pose['pitch'],final_pose['world_time']):
        raise RuntimeError('Camera or world time changed during capture')
    metrics = analyze(output,args.pid,args.warmup)
    metadata = {'run_id':runid,'variant':variant,'specification':spec,'pack_sha256':packhash,
                'iris':iris,'custom_options':custom,'requested_options':requested_options,
                'scene':args.scene,'pose':pose,
                'resolution':{'width':resolution[0],'height':resolution[1]},'pid':args.pid,
                'options':props(GAME/'options.txt'),'dh_config':(GAME/'config/DistantHorizons.toml').read_text(),
                'renderer':renderers[-1],'before':before,'after':after,'presentmon_command':command,
                'frames':frames,'metrics':metrics,'presentmon_stdout':done.stdout,
                'presentmon_stderr':done.stderr,'own_etw_session_cleanup':cleanup}
    dump(output.with_suffix('.capture.json'),metadata)
    print('RESULT '+runid+' '+json.dumps(metrics),flush=True)
    return metadata


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pid',type=int,required=True)
    p.add_argument('--presentmon',type=Path,required=True)
    p.add_argument('--cases',type=Path,required=True,help='JSON map of variant to exact pack/artifact/enabled/revision')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--scene',choices=SCENES,required=True)
    p.add_argument('--sequence',nargs='+',default=['original','off','off','original'])
    p.add_argument('--seconds',type=int,default=18)
    p.add_argument('--warmup',type=float,default=2)
    p.add_argument('--settle-ticks',type=int,default=160)
    p.add_argument('--scene-settle-ticks',type=int,default=400)
    args=p.parse_args();args.output=args.output.resolve();args.output.mkdir(parents=True,exist_ok=True)
    cases=json.loads(args.cases.read_text(encoding='utf-8-sig'))
    runtime=snapshot(args.pid)
    active_session=ctypes.WinDLL('kernel32').WTSGetActiveConsoleSessionId()
    if runtime['memory']['name'] != 'javaw.exe' or not runtime['memory']['matches_instance']:
        raise RuntimeError('PID is not the requested ShaderBench Java process')
    if runtime['memory']['session_id'] != active_session:
        raise RuntimeError('ShaderBench is outside the active physical-console session')
    renderer_lines=[line for line in (GAME/'logs/latest.log').read_text(encoding='utf8',errors='replace').splitlines() if 'OpenGL Renderer:' in line]
    if not renderer_lines or 'NVIDIA GeForce RTX 4070' not in renderer_lines[-1]:
        raise RuntimeError('RTX 4070 OpenGL renderer required before changing the scene or pack')
    dump(args.output/'preflight.json', {'runtime':runtime,'active_console_session':active_session,'renderer':renderer_lines[-1]})
    b=Bench(timeout=30)
    b.send('mouse free');b.send('closescreen');b.send('hud off')
    x,y,z,yaw,pitch,clock=SCENES[args.scene]
    b.send(f'cmd execute in minecraft:overworld run tp @s {x} {y} {z} {yaw} {pitch}')
    b.send(f'cmd time set {clock}');b.send('cmd weather clear');b.send('wait 10')
    b.send('waitchunks 600');b.send(f'wait {args.scene_settle_ticks}')
    results=[]
    for index,variant in enumerate(args.sequence,1):
        results.append(capture(args,b,cases[variant],variant,index))
        dump(args.output/f'{args.scene}-results.json',results)
    b.close()


if __name__=='__main__': main()
