#!/usr/bin/env python3
"""Reproduce selective/full invalidation on actual TCE and CHA passes.

Build opt/FileCheck/JavaTypeQueryTests first. This script never builds or edits
the checkout. Generated IR and callback replay data, all commands, raw timings,
source identity, and verification output are retained in a fresh output folder.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import shlex
import statistics
import subprocess
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generate(out, kind, functions, sites, depth):
    """Use a shared select DAG or a leaf, followed by real Java call sites."""
    static = kind != "virtual"
    mixed = kind == "tce-cha"
    lines = [
        '@jeandle.personality = global ptr null',
        '@oop_handle_member_5 = external global ptr addrspace(1)',
        'declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)',
        'declare hotspotcc ptr addrspace(1) @link(ptr addrspace(1), ptr addrspace(1)) #1 gc "hotspotgc"',
        'declare hotspotcc ptr addrspace(1) @virtual(ptr addrspace(1)) #1 gc "hotspotgc"',
    ]
    for f in range(functions):
        lines += [
            f'define hotspotcc ptr addrspace(1) @caller{f}(ptr addrspace(1) "java-klass"="22" %a, ptr addrspace(1) "java-klass"="22" %b, i1 %c) #0 gc "hotspotgc" personality ptr @jeandle.personality {{',
            'entry:',
            '  %member = load ptr addrspace(1), ptr @oop_handle_member_5',
        ]
        value = '%a'
        for i in range(depth):
            lines.append(f'  %s{i} = select i1 %c, ptr addrspace(1) {value}, ptr addrspace(1) %b')
            value = f'%s{i}'
        if mixed:
            lines.append(f'  %check = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 22 to ptr), ptr addrspace(1) nonnull {value})')
        for i in range(sites):
            target = f'@link(ptr addrspace(1) {value}, ptr addrspace(1) %member)' if static else f'@virtual(ptr addrspace(1) {value})'
            lines += [
                f'  %r{i} = invoke hotspotcc ptr addrspace(1) {target} #{i+2} [ "deopt"(i64 0, i32 7, i32 7) ] to label %next{i} unwind label %unwind',
                f'next{i}:',
            ]
        lines += [f'  ret ptr addrspace(1) %r{sites-1}', 'unwind:', '  %lp = landingpad i64 cleanup', '  ret ptr addrspace(1) null', '}']
    lines += ['attributes #0 = { "java-method"="100" }', 'attributes #1 = { "java-method"="200" }']
    for i in range(sites):
        attrs = '"bytecode"="invokehandle" "monomorphic-target" "mh-intrinsic-name"="_linkToStatic"' if static else '"bytecode"="invokevirtual"'
        lines.append(f'attributes #{i+2} = {{ {attrs} "declared-holder"="300" "statepoint-id"="{42+i}" "statepoint-num-patch-bytes"="5" }}')
    lines += ['!java-method-compilation = !{}', '!static-call-patch-size = !{!0}', '!0 = !{i32 5}']
    ir = out / f'{kind}.ll'
    ir.write_text('\n'.join(lines) + '\n')
    callbacks = [
        'GetCHAOptInfo 100 200 300 0 false 5 5 = (601, 700, 13, "Optimized_target")',
        'GetCHAOptInfo 100 200 300 22 false 0 -1 = (22, 700, 48, "Optimized_target")',
        'GetCHAOptInfo 100 200 300 22 true 0 -1 = (22, 700, 48, "Optimized_target")',
        'GetSignatureArgType 700 -1 = 12',
        'GetSignatureArgType 700 0 = 12',
        'GetSignatureArgTypeKlass 700 0 = 22',
        'IsSubtype 22 22 = true',
        'IsInterface 22 = false',
        'IsObjectKlass 22 = false',
        'IsEffectivelyFinal 22 = false',
        'GetSecondarySupers 22 = []',
        'GetCommonSuperKlass 22 22 = 22',
    ]
    for i in range(sites):
        callbacks += [f'UpdateCallSite {42+i} 0 true 700 = true', f'UpdateCallSite {42+i} 2 false 700 = true']
    cb = out / f'{kind}.cblog'
    cb.write_text('\n'.join(callbacks) + '\n')
    passes = 'type-check-elimination,cha-devirtualization' if mixed else 'cha-devirtualization'
    return ir, cb, passes


def counters(stderr):
    return {key: int(value) for key, value in re.findall(r'^  ([^:\n]+): (\d+)$', stderr, re.M)}


def paired_interval(rows, reference, count):
    """Bootstrap paired rounds; interval estimates this run's timing noise."""
    pairs = []
    for i in range(count):
        group = {r['mode']: r['wall_ns'] for r in rows if r['round'] == i}
        pairs.append((group['selective'], group[reference]))
    rng = random.Random(71)
    estimates = []
    for _ in range(2000):
        sample = rng.choices(pairs, k=count)
        estimates.append(100 * (1 - statistics.median(p[0] for p in sample) /
                                statistics.median(p[1] for p in sample)))
    estimates.sort()
    return [estimates[50], estimates[1949]]


def run(command, prefix, output=True):
    prefix.with_suffix('.command').write_text(shlex.join(command) + '\n')
    start = time.perf_counter_ns()
    result = subprocess.run(command, capture_output=True, text=True)
    elapsed = time.perf_counter_ns() - start
    prefix.with_suffix('.stderr').write_text(result.stderr)
    if output:
        prefix.with_suffix('.stdout').write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}); see {prefix}.stderr')
    return elapsed, result


def regress(root, opt, out):
    """Replay every TCE/CHA RUN pipeline; reject unsupported lit syntax."""
    check = opt.parent / 'FileCheck'
    rows = []
    modes = {'selective': [], 'full': ['-jeandle-java-type-force-full-invalidation'],
             'original': ['-jeandle-disable-java-type-cache'], 'verify': ['-jeandle-verify-java-type-cache']}
    for mode, flags in modes.items():
        dest = out / mode
        dest.mkdir(parents=True)
        for directory in ['type-check-elimination', 'cha-devirtualization']:
            for path in sorted((root / 'llvm/test/Jeandle' / directory).glob('*.ll')):
                commands = [line[7:] for line in path.read_text().splitlines() if line.startswith('; RUN: ')]
                if not commands:
                    raise RuntimeError(f'Missing RUN line: {path}')
                for i, command in enumerate(commands):
                    if not command.startswith('opt ') or command.endswith('\\'):
                        raise RuntimeError(f'Unsupported RUN syntax: {path}: {command}')
                    command = shlex.join([str(opt), '-verify-each', *flags]) + ' ' + command[4:]
                    command = command.replace('%S', shlex.quote(str(path.parent))).replace('%s', shlex.quote(str(path)))
                    if re.search(r'%[A-Za-z{]', command):
                        raise RuntimeError(f'Unsupported substitution: {command}')
                    command = re.sub(r'\bFileCheck\b', lambda _: shlex.quote(str(check)), command)
                    prefix = dest / f'{directory}-{path.stem}-{i}'
                    run(['bash', '-o', 'pipefail', '-c', command], prefix)
                    rows.append({'mode': mode, 'fixture': str(path.relative_to(root)), 'run': i, 'passed': True})
        print(f'{mode}: {sum(r["mode"] == mode for r in rows)} regression commands passed', flush=True)
    (out / 'matrix.json').write_text(json.dumps(rows, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--opt', type=Path, required=True)
    parser.add_argument('--baseline-opt', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=11)
    parser.add_argument('--functions', type=int, default=16)
    parser.add_argument('--sites', type=int, default=24)
    parser.add_argument('--depth', type=int, default=256)
    parser.add_argument('--regress', action='store_true')
    args = parser.parse_args()
    if min(args.repeats, args.functions, args.sites) < 1 or args.depth < 0:
        parser.error('counts must be positive; depth must be nonnegative')
    args.opt = args.opt.resolve()
    if args.baseline_opt:
        args.baseline_opt = args.baseline_opt.resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parents[3]
    patch = subprocess.check_output(['git', 'diff', 'HEAD', '--binary'], cwd=root)
    (out / 'worktree.patch').write_bytes(patch)
    tracked = subprocess.check_output(['git', 'ls-files', 'llvm/utils/jeandle', 'llvm/lib/Analysis/Jeandle', 'llvm/include/llvm/Analysis/Jeandle', 'llvm/lib/Transforms/Jeandle', 'llvm/unittests/IR/JavaTypeQueryTest.cpp'], cwd=root, text=True).splitlines()
    manifest = {
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
        'platform': platform.platform(), 'cpu': platform.processor(),
        'cpu_affinity': sorted(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else None,
        'options': {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        'opt_sha256': digest(args.opt), 'script_sha256': digest(Path(__file__)),
        'sources': {p: digest(root / p) for p in tracked},
        'baseline_sha256': digest(args.baseline_opt) if args.baseline_opt else None,
        'timing': 'two warmups per mode; seeded shuffled mode order in each round; subprocess wall time includes startup, parse, passes and stats; verification excluded',
    }
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (out / 'reproduce.py').write_bytes(Path(__file__).read_bytes())
    if args.regress:
        regress(root, args.opt, out / 'regression')
    # Statistics are off by default; the main binary enables them to emit counters,
    # while the baseline binary may predate the switch.
    stats = ['-jeandle-java-type-stats']
    modes = {'selective': (args.opt, [*stats]),
             'full': (args.opt, [*stats, '-jeandle-java-type-force-full-invalidation'])}
    if args.baseline_opt:
        modes['baseline'] = (args.baseline_opt, [])
    rng = random.Random(20261014)
    summaries = {}
    for kind, depth in [('static', args.depth), ('tce-cha', args.depth), ('leaf', 0), ('virtual', 0)]:
        dest = out / kind
        dest.mkdir()
        ir, cb, passes = generate(dest, kind, args.functions, args.sites, depth)
        common = [f'-passes=function({passes}),print<java-type-analysis-summary>', f'-jeandle-vm-callback-log={cb}', str(ir)]
        outputs = {}
        checks = dict(modes, original=(args.opt, [*stats, '-jeandle-disable-java-type-cache']),
                      verify=(args.opt, [*stats, '-jeandle-verify-java-type-cache']))
        correctness = {}
        for mode, (binary, flags) in checks.items():
            _, result = run([str(binary), '-S', '-verify-each', *flags, *common], dest / f'check-{mode}')
            outputs[mode] = result.stdout
            correctness[mode] = counters(result.stderr)
            actual = len(re.findall(r'invoke hotspotcc .* @Optimized_target\(', result.stdout))
            if actual != args.functions * args.sites:
                raise RuntimeError(f'{kind}/{mode}: only {actual} sites transformed')
        if len(set(outputs.values())) != 1:
            raise RuntimeError(f'Output IR differs for {kind}; inspect check-*.stdout')
        if correctness['verify'].get('verifications', 0) <= 0:
            raise RuntimeError(f'{kind}: benchmark must execute differential verification')
        rows = []
        for iteration in range(-2, args.repeats):
            order = list(modes)
            rng.shuffle(order)
            for mode in order:
                binary, flags = modes[mode]
                elapsed, result = run([str(binary), '-disable-output', *flags, *common], dest / f'time-{iteration}-{mode}', output=False)
                rows.append({'round': iteration, 'mode': mode, 'wall_ns': elapsed, 'counters': counters(result.stderr)})
        (dest / 'samples.json').write_text(json.dumps(rows, indent=2) + '\n')
        summary = {'functions': args.functions, 'sites_per_function': args.sites, 'select_depth': depth, 'IR_equal': True, 'verification': correctness['verify'], 'modes': {}}
        for mode in modes:
            samples = [r for r in rows if r['round'] >= 0 and r['mode'] == mode]
            walls = [r['wall_ns'] for r in samples]
            timekeys = ['total query time (ns)', 'total invalidation time (ns)']
            median = {k: statistics.median([r['counters'][k] for r in samples]) for k in timekeys if k in samples[0]['counters']}
            summary['modes'][mode] = {'wall_median_ns': statistics.median(walls), 'wall_min_ns': min(walls), 'wall_max_ns': max(walls), 'median_times': median, 'counters': samples[0]['counters']}
        sel = summary['modes']['selective']['wall_median_ns']
        summary['wall_reduction_vs_full_pct'] = 100 * (1 - sel / summary['modes']['full']['wall_median_ns'])
        summary['wall_reduction_vs_full_paired_bootstrap_95pct'] = paired_interval(rows, 'full', args.repeats)
        if 'baseline' in modes:
            summary['wall_reduction_vs_baseline_pct'] = 100 * (1 - sel / summary['modes']['baseline']['wall_median_ns'])
            summary['wall_reduction_vs_baseline_paired_bootstrap_95pct'] = paired_interval(rows, 'baseline', args.repeats)
        summaries[kind] = summary
        (out / 'summary.json').write_text(json.dumps(summaries, indent=2) + '\n')
        print(f'{kind}: wall time vs full {summary["wall_reduction_vs_full_pct"]:+.2f}%; verification passed; identical output IR', flush=True)
    if patch != subprocess.check_output(['git', 'diff', 'HEAD', '--binary'], cwd=root):
        raise RuntimeError('Working tree changed during measurement; rerun')
    for path, expected in manifest['sources'].items():
        if digest(root / path) != expected:
            raise RuntimeError(f'Source changed during measurement: {path}')
    if digest(args.opt) != manifest['opt_sha256']:
        raise RuntimeError('opt changed during measurement; rerun')
    (out / 'SUCCESS').write_text('Correctness checks and measurements completed.\n')
    print(f'Evidence: {out}')


if __name__ == '__main__':
    main()
