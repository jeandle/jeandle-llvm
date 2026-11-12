#!/usr/bin/env python3
"""Independently check a completed run without rerunning timed workloads."""
import argparse
from collections import Counter
import hashlib
import itertools
import json
from pathlib import Path
import statistics as st

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('results', type=Path)
    args = p.parse_args()
    if __import__('sys').flags.optimize:
        p.error('Python optimization disables required audit checks')
    r = args.results.resolve()
    root = Path(__file__).resolve().parent
    m = json.loads((r/'manifest.json').read_text())
    assert (r/'SUCCESS').is_file(), 'run did not complete'
    assert sha(root/'run.py') == m['runner_sha256'], 'runner changed'
    for name, expected in m['frozen_inputs'].items():
        assert sha(root/'inputs'/name) == expected, name
    for name, expected in m['native_source_hashes'].items():
        assert sha(root/'native'/name) == expected, name
    versions = m['versions']
    for v, cfg in versions.items():
        assert sha(cfg['opt']) == cfg['opt_sha256'], v
        assert sha(cfg['replay']) == cfg['replay_sha256'], v
    diags = json.loads((r/'diagnostics.json').read_text())
    for name, expected in m['input_hashes'].items():
        if isinstance(expected, str):
            for v in versions:
                d = diags[name+':'+v]
                assert d['queries'] == 64 and d['checksum'] == 1408
                assert sha(r/'native'/v/f'{name}.ll') == expected
        else:
            for key, suffix in [('ir', '.ll'), ('callback', '.cblog')]:
                assert sha(root/'inputs/opt-inputs'/name/(name+suffix)) == expected[key]
            outputs = []
            for v in versions:
                data = (r/f'{name}-{v}-diagnostic.ll').read_bytes()
                assert data == (r/f'{name}-{v}-verification.ll').read_bytes()
                outputs.append(data)
            assert all(data == outputs[0] for data in outputs)
    rows = [json.loads(line) for line in (r/'samples.jsonl').read_text().splitlines()]
    formal = [row for row in rows if not row['warmup']]
    counts = Counter((x['case'], x['phase'], x['version']) for x in formal)
    assert len(m['input_hashes']) == 10
    assert len(formal) == 10 * (2*m['aa_repeats'] + len(versions)*m['repeats'])
    for name in m['input_hashes']:
        assert counts[name, 'aa', 'base'] == 2*m['aa_repeats']
        for v in versions:
            assert counts[name, 'comparison', v] == m['repeats']
    summary = json.loads((r/'summary.json').read_text())
    assert len(summary) == 10 and {s['case'] for s in summary} == set(m['input_hashes'])
    for entry in summary:
        case_rows = [x for x in formal if x['case'] == entry['case']]
        minimum = min(x['cpu_s'] for x in case_rows)
        assert entry['min_cpu_s'] == minimum
        pairs = {}
        for x in case_rows:
            if x['phase'] == 'comparison':
                pairs.setdefault(x['round'], {})[x['version']] = x
        assert len(pairs) == m['repeats'] and all(set(x) == set(versions) for x in pairs.values())
        for v in versions:
            assert entry['cost_ms'][v] == st.median(x[v]['cost'] for x in pairs.values())*1000
        for left, right in itertools.combinations(versions, 2):
            change = st.median(100*(x[right]['cost']/x[left]['cost']-1) for x in pairs.values())
            verdict = entry['comparisons'][left+'->'+right]
            assert verdict['change_pct'] == change
            if minimum < .2:
                assert verdict['verdict'] == 'inconclusive'
    result = {'formal_samples': len(formal), 'min_cpu_s': min(x['cpu_s'] for x in formal),
              'sample_duration_ok': all(x['cpu_s'] >= .2 for x in formal),
              'input_and_binary_hashes_match': True, 'opt_ir_byte_identical': True}
    (r/'audit.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))

if __name__ == '__main__':
    main()
